import Foundation
import Security

public enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

/// Generic-password storage under service "ai.karko.sadaa".
public enum Keychain {
    private static let service = "ai.karko.sadaa"

    /// Upsert via SecItemUpdate-then-SecItemAdd so the stored key can't be
    /// lost between a delete and an add.
    /// Deliberately no kSecAttrAccessible / data-protection keychain: those
    /// are iOS semantics; on macOS file-based login keychains the attribute
    /// is ignored, and opting into the data-protection keychain would need
    /// entitlements an ad-hoc-signed app doesn't have.
    public static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        /// Returns nil both when the item doesn't exist and on any other
        /// SecItemCopyMatching failure; callers treat all of those as
        /// "not configured".
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// True if an item exists for `account`, WITHOUT returning (decrypting) its
    /// data. This matters on the main thread: get(), with kSecReturnData, can
    /// make securityd put up a keychain authorization prompt that blocks the
    /// caller until the user answers it (which happens after a re-signed
    /// reinstall). An existence check decrypts nothing, so it never prompts and
    /// is safe to call at launch to decide whether a provider is configured.
    public static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: false,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
