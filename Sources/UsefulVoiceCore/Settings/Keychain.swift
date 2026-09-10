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

    /// The outcome of reading an item.
    ///
    /// Why this is not just `String?`: a `nil` conflated four different
    /// situations. "You have not set a key", "your keychain is locked", "you
    /// dismissed the authorization prompt" and "the item is corrupt" all looked
    /// identical to the caller, so the app told users "No transcription provider
    /// configured" when the truth was that it had been refused permission to read
    /// the key it had. The user's only recourse — re-entering a working key — was
    /// exactly the wrong one.
    public enum Lookup: Equatable {
        /// The item exists and its data decoded.
        case found(String)
        /// No item is stored under this account. The only case that means
        /// "not configured".
        case absent
        /// The item may exist but could not be read, or the prompt was dismissed.
        /// Carries an explanation suitable for showing the user.
        case unavailable(String)

        public var value: String? {
            if case .found(let value) = self { return value }
            return nil
        }
    }

    /// Reads an item while distinguishing absence from refusal.
    public static func lookup(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return classify(status: status, result: result)
    }

    /// Turns a `SecItemCopyMatching` result into a `Lookup`.
    ///
    /// Split out from `lookup` so every status branch is testable without a real
    /// keychain. That matters because these branches are the whole point of the
    /// type: the interesting ones — locked, denied — cannot be produced on demand
    /// against the live keychain in a test.
    public static func classify(status: OSStatus, result: AnyObject?) -> Lookup {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                // The item exists but is not readable as data, which means the
                // stored value is not usable rather than that nothing is stored.
                return .unavailable("the stored key could not be read")
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return .unavailable("the stored key is empty or not valid text")
            }
            return .found(text)
        case errSecItemNotFound:
            return .absent
        case errSecUserCanceled:
            return .unavailable("keychain access was denied")
        case errSecAuthFailed:
            return .unavailable("keychain authentication failed")
        case errSecInteractionNotAllowed:
            return .unavailable("the keychain is locked")
        default:
            return .unavailable("the keychain returned status \(status)")
        }
    }

    /// The stored value, or `nil` when it is absent *or* unreadable.
    ///
    /// Prefer `lookup(account:)` anywhere the difference matters — which is
    /// anywhere the result is shown to a user.
    public static func get(account: String) -> String? {
        lookup(account: account).value
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
