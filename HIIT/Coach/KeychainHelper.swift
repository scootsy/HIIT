import Foundation
import Security

/// Minimal Keychain wrapper for the (optional) Anthropic API key — the key
/// never leaves the device except in requests the user explicitly triggers.
enum KeychainHelper {
    private static let service = "com.scootsy.HIIT.apikey"
    private static let account = "anthropic"

    /// Returns false when the write failed, so the UI can say so instead of
    /// showing "Saved ✓" for a key that never landed. Updates in place rather
    /// than delete-then-add: the old version destroyed the existing key first,
    /// so a failed add left the user with no key at all.
    @discardableResult
    static func save(_ value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return true
        }
        let payload: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, payload as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // ThisDeviceOnly keeps the key out of device backups and migrations.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
