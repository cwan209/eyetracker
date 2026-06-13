import CryptoKit
import Foundation
import Security

/// Load-or-create the 256-bit AES key in the login Keychain (U13, KTD10).
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: device-bound, non-syncing,
/// readable only while unlocked. The encrypted model blob lives on disk; only
/// this key lives in the Keychain.
public enum KeychainKey {
    public enum KeyError: Error { case unexpectedStatus(OSStatus) }

    private static let account = "com.gazefocus.modelKey"

    /// Returns the stored key, creating and persisting a fresh one on first use.
    public static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try load() { return existing }
        let key = SymmetricKey(size: .bits256)
        try store(key)
        return key
    }

    public static func remove() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeyError.unexpectedStatus(status)
        }
    }

    private static func store(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.unexpectedStatus(status) }
    }
}
